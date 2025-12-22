
#include <jc_test/jc_test.h>

#include "ddf/ddf_struct.h"

static dmStructDDF::Struct::FieldsEntry* FindEntry(dmStructDDF::Struct* message, const char* key)
{
    for (uint32_t i = 0; i < message->m_Fields.m_Count; ++i)
    {
        if (strcmp(message->m_Fields[i].m_Key, key) == 0)
            return &message->m_Fields[i];
    }

    return 0;
}

void TestStructSimple(const char* msg, uint32_t msg_size)
{
    dmStructDDF::Struct* message;
    dmDDF::Result e = dmDDF::LoadMessage((void*) msg, msg_size, &dmStructDDF_Struct_DESCRIPTOR, (void**)&message);
    ASSERT_EQ(dmDDF::RESULT_OK, e);

    dmStructDDF::Struct::FieldsEntry* hello = FindEntry(message, "hello");
    ASSERT_STREQ("world", hello->m_Value->m_Kind.m_StringValue);

    dmStructDDF::Struct::FieldsEntry* number = FindEntry(message, "number");
    ASSERT_NEAR(1337.0, number->m_Value->m_Kind.m_NumberValue, 0.001);

    dmStructDDF::Struct::FieldsEntry* boolean = FindEntry(message, "boolean");
    ASSERT_TRUE(boolean->m_Value->m_Kind.m_BoolValue);

    dmStructDDF::Struct::FieldsEntry* nothing = FindEntry(message, "nothing");
    ASSERT_EQ(dmStructDDF::NULL_VALUE, nothing->m_Value->m_Kind.m_NullValue);
}

void TestStructNested(const char* msg, uint32_t msg_size)
{
    dmStructDDF::Struct* message;
    dmDDF::Result e = dmDDF::LoadMessage((void*) msg, msg_size, &dmStructDDF_Struct_DESCRIPTOR, (void**)&message);
    ASSERT_EQ(dmDDF::RESULT_OK, e);

    dmStructDDF::Struct::FieldsEntry* user = FindEntry(message, "user");

    dmStructDDF::Struct::FieldsEntry* id = FindEntry(&user->m_Value->m_Kind.m_StructValue, "id");
    ASSERT_NEAR(123.0, id->m_Value->m_Kind.m_NumberValue, 0.001);

    dmStructDDF::Struct::FieldsEntry* name = FindEntry(&user->m_Value->m_Kind.m_StructValue, "name");
    ASSERT_STREQ("Mr.X", name->m_Value->m_Kind.m_StringValue);
}

void TestStructList(const char* msg, uint32_t msg_size)
{
    dmStructDDF::Struct* message;
    dmDDF::Result e = dmDDF::LoadMessage((void*) msg, msg_size, &dmStructDDF_Struct_DESCRIPTOR, (void**)&message);
    ASSERT_EQ(dmDDF::RESULT_OK, e);

    dmStructDDF::Struct::FieldsEntry* values = FindEntry(message, "values");
    dmStructDDF::ListValue* list = values->m_Value->m_Kind.m_ListValue;

    ASSERT_EQ(3, list->m_Values.m_Count);
    ASSERT_NEAR(1.0, list->m_Values[0].m_Kind.m_NumberValue, 0.001);
    ASSERT_STREQ("two", list->m_Values[1].m_Kind.m_StringValue);
    ASSERT_FALSE(list->m_Values[2].m_Kind.m_BoolValue);
}

void TestStructJSON(const char* msg, uint32_t msg_size)
{
    dmStructDDF::Struct* message;
    dmDDF::Result e = dmDDF::LoadMessage((void*) msg, msg_size, &dmStructDDF_Struct_DESCRIPTOR, (void**)&message);
    ASSERT_EQ(dmDDF::RESULT_OK, e);

    dmStructDDF::Struct::FieldsEntry* name = FindEntry(message, "name");
    ASSERT_STREQ("engine", name->m_Value->m_Kind.m_StringValue);

    dmStructDDF::Struct::FieldsEntry* version = FindEntry(message, "version");
    ASSERT_NEAR(3.0, version->m_Value->m_Kind.m_NumberValue, 0.001);

    dmStructDDF::Struct::FieldsEntry* features = FindEntry(message, "features");
    ASSERT_EQ(2, features->m_Value->m_Kind.m_ListValue->m_Values.m_Count);

    dmStructDDF::Struct::FieldsEntry* config = FindEntry(message, "config");
    ASSERT_TRUE(config->m_Value->m_Kind.m_StructValue.m_Fields[0].m_Value->m_Kind.m_BoolValue);

    dmStructDDF::Struct::FieldsEntry* debug = FindEntry(&config->m_Value->m_Kind.m_StructValue, "debug");
    ASSERT_TRUE(debug->m_Value->m_Kind.m_BoolValue);
}
